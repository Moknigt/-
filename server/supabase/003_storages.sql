-- STEP 3 of 3, PART 1 of 4 (storages on Cloudflare R2: the HARD LIMIT lives here). Run AFTER 001_accounts.sql (002 is independent).
-- Part 2 = the four Edge Functions (upload-url, upload-complete, play-url, purge-deleted), part 3 = the apps, part 4 = STORAGES_SETUP.md.
--
-- WHY THIS FILE IS STRICT: Cloudflare R2 has NO spending cap of its own. Its free tier is 10 GB-month PER CLOUDFLARE ACCOUNT (not per bucket),
-- so every byte that goes in must be accounted for HERE, before the app is given an upload link:
--   * 8 GiB per storage   : CHECK on storages.limit_bytes (nobody can raise it, not even the admin) + the reserve function + a trigger.
--   * 8 GiB per account   : all storages with the same account_ref together (they share ONE free 10 GB).
--   * 1 GiB per file      : max_file_bytes().
--   * space is RESERVED first (atomic, row lock + advisory lock per account); a reservation that is never completed expires after 2 hours.
--   * the actual size is checked after the upload; a bigger or orphan file is counted and queued for deletion, never trusted.
--   * used_bytes only goes down after R2 really deleted the file (queue_done). A file that cannot be deleted keeps counting.
--   * reconcile_storage compares our counter with the real bucket size and switches the storage OFF when they disagree or it is nearly full.
-- R2 keys are NEVER in a table: secret_name is only the NAME PREFIX of the Edge Function secrets (R2_A -> R2_A_ACCESS_KEY_ID, R2_A_SECRET_ACCESS_KEY).
-- Every function below is service_role only (the Edge Functions). The apps only READ the safe columns of storages.

-- ---------- the numbers (the Edge Functions use the same ones) ----------
create or replace function public.storage_cap_bytes() returns bigint language sql immutable as $$ select 8589934592::bigint $$;   -- 8 GiB
create or replace function public.max_file_bytes()    returns bigint language sql immutable as $$ select 1073741824::bigint $$;   -- 1 GiB

-- ---------- storages ----------
create table if not exists public.storages (
  id text primary key default gen_random_uuid()::text,       -- text on purpose: lesson_sources.storage_id (step 1) is text
  name text not null,
  kind text not null default 'r2' check (kind = 'r2'),
  endpoint text not null,                                    -- https://<cloudflare-account-id>.r2.cloudflarestorage.com
  bucket text not null,                                      -- a PRIVATE bucket (never public)
  account_ref text not null check (length(account_ref) between 1 and 64),   -- the Cloudflare account id: same value = same free 10 GB
  secret_name text not null check (secret_name ~ '^[A-Z][A-Z0-9_]{1,31}$'),  -- NAME prefix of the secrets, never a key
  limit_bytes bigint not null default 8589934592 check (limit_bytes > 0 and limit_bytes <= 8589934592),   -- HARD: 8 GiB at most
  used_bytes bigint not null default 0 check (used_bytes >= 0),
  reserved_bytes bigint not null default 0 check (reserved_bytes >= 0),
  active boolean not null default true,
  sort_order int not null default 0,                         -- uploads go to the first active storage (lowest sort_order) with room
  created_at timestamptz not null default now()
);

-- Last line of defence: NO statement (not even a manual one from the dashboard) can raise reserved_bytes above the limits.
create or replace function public.storages_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare other bigint;
begin
  if new.reserved_bytes > old.reserved_bytes then
    if new.used_bytes + new.reserved_bytes > new.limit_bytes then
      raise exception 'storage_full' using errcode = '53100';
    end if;
    select coalesce(sum(used_bytes + reserved_bytes), 0) into other
      from public.storages where account_ref = new.account_ref and id <> new.id;
    if other + new.used_bytes + new.reserved_bytes > public.storage_cap_bytes() then
      raise exception 'account_full' using errcode = '53100';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists storages_guard on public.storages;
create trigger storages_guard before update on public.storages
  for each row execute function public.storages_guard();

-- ---------- upload reservations ----------
create table if not exists public.upload_reservations (
  id uuid primary key default gen_random_uuid(),
  storage_id text not null references public.storages(id),
  lesson_id uuid references public.lessons(id) on delete set null,   -- lesson deleted meanwhile: the reservation just expires
  owner uuid not null references public.profiles(id),
  storage_key text not null,
  size_bytes bigint not null check (size_bytes > 0 and size_bytes <= 1073741824),
  status text not null default 'reserved' check (status in ('reserved','completed','released','expired','rejected')),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '2 hours',   -- the presigned upload link must expire BEFORE this
  completed_at timestamptz
);
create index if not exists upload_reservations_open on public.upload_reservations(owner, status);
create index if not exists upload_reservations_lesson on public.upload_reservations(lesson_id, status);

-- ---------- files that really are in a bucket (size as measured after the upload) ----------
create table if not exists public.stored_files (
  storage_id text not null references public.storages(id),
  storage_key text not null,
  size_bytes bigint not null check (size_bytes >= 0),
  lesson_id uuid,
  created_at timestamptz not null default now(),
  primary key (storage_id, storage_key)
);

-- ---------- delete queue: deleting a lesson (or replacing its file) also deletes the file in R2 ----------
create table if not exists public.file_delete_queue (
  id bigint generated always as identity primary key,
  storage_id text not null references public.storages(id),
  storage_key text not null,
  size_bytes bigint not null check (size_bytes >= 0),
  status text not null default 'pending' check (status in ('pending','done','dead')),   -- dead = 10 failed tries; it keeps counting in used_bytes
  attempts int not null default 0,
  last_error text,
  enqueued_at timestamptz not null default now(),
  done_at timestamptz
);
create unique index if not exists queue_one_pending on public.file_delete_queue(storage_id, storage_key) where status = 'pending';

create table if not exists public.storage_log (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  storage_id text,
  event text not null,
  detail jsonb not null default '{}'::jsonb
);

-- ---------- link lesson_sources (step 1) to storages, and protect it ----------
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'lesson_sources_storage_fk') then
    alter table public.lesson_sources
      add constraint lesson_sources_storage_fk foreign key (storage_id) references public.storages(id) on delete restrict;
  end if;
end $$;

-- A teacher can write lesson_sources from the app (step 1 policy). Without this guard he could point his lesson at ANOTHER lesson's file
-- and watch it through play-url. A storage file can only be attached to the lesson it was uploaded for.
create or replace function public.sources_storage_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.storage_id is null and new.storage_key is null then return new; end if;
  if tg_op = 'UPDATE' then
    if new.storage_id is not distinct from old.storage_id and new.storage_key is not distinct from old.storage_key then return new; end if;
  end if;
  if not exists (select 1 from public.stored_files f
                  where f.storage_id = new.storage_id and f.storage_key = new.storage_key and f.lesson_id = new.lesson_id) then
    raise exception 'this storage file does not belong to this lesson' using errcode = '42501';
  end if;
  return new;
end $$;
drop trigger if exists sources_storage_guard on public.lesson_sources;
create trigger sources_storage_guard before insert or update on public.lesson_sources
  for each row execute function public.sources_storage_guard();

-- Lesson deleted (cascade), source row deleted, or file replaced / cleared: queue the OLD file for deletion.
create or replace function public.queue_file_on_source_change() returns trigger
language plpgsql security definer set search_path = public as $$
declare f public.stored_files;
begin
  if old.storage_id is not null and old.storage_key is not null then
    if tg_op = 'DELETE' or new.storage_id is distinct from old.storage_id or new.storage_key is distinct from old.storage_key then
      select * into f from public.stored_files where storage_id = old.storage_id and storage_key = old.storage_key;
      if found then
        insert into public.file_delete_queue(storage_id, storage_key, size_bytes)
        values (f.storage_id, f.storage_key, f.size_bytes)
        on conflict (storage_id, storage_key) where status = 'pending' do nothing;
      end if;
    end if;
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;
drop trigger if exists lesson_sources_queue on public.lesson_sources;
create trigger lesson_sources_queue after delete or update of storage_id, storage_key on public.lesson_sources
  for each row execute function public.queue_file_on_source_change();

-- ---------- reservations: release / expire ----------
create or replace function public._release_reservation(p_id uuid, p_status text) returns boolean
language plpgsql security definer set search_path = public as $$
declare r public.upload_reservations;
begin
  update public.upload_reservations set status = p_status where id = p_id and status = 'reserved' returning * into r;
  if not found then return false; end if;
  update public.storages set reserved_bytes = greatest(reserved_bytes - r.size_bytes, 0) where id = r.storage_id;
  return true;
end $$;

create or replace function public.expire_reservations() returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  for r in select id from public.upload_reservations where status = 'reserved' and expires_at < now() for update skip locked loop
    if public._release_reservation(r.id, 'expired') then n := n + 1; end if;
  end loop;
  return n;
end $$;

-- ---------- 1) reserve space (called by upload-url, with the teacher id taken from his verified token) ----------
-- Returns {ok:true, reservationId, storageId, endpoint, bucket, secretName, key, sizeBytes, expiresAt}
--      or {ok:false, reason: bad_size | too_large | not_allowed | not_your_lesson | too_many_open | full}
create or replace function public.reserve_upload(p_owner uuid, p_lesson uuid, p_size bigint, p_ext text default 'mp4') returns json
language plpgsql security definer set search_path = public as $$
declare
  s record; st public.storages; r public.upload_reservations;
  got boolean := false; acct bigint; ext text; k text; rid uuid; n int;
begin
  if p_size is null or p_size <= 0 then return json_build_object('ok', false, 'reason', 'bad_size'); end if;
  if p_size > public.max_file_bytes() then
    return json_build_object('ok', false, 'reason', 'too_large', 'maxBytes', public.max_file_bytes());
  end if;
  if not exists (select 1 from public.profiles where id = p_owner and role in ('teacher','admin') and active) then
    return json_build_object('ok', false, 'reason', 'not_allowed');
  end if;
  if not exists (select 1 from public.lessons l
                  where l.id = p_lesson and l.src = 'up'
                    and (l.owner = p_owner or exists (select 1 from public.profiles a where a.id = p_owner and a.role = 'admin' and a.active))) then
    return json_build_object('ok', false, 'reason', 'not_your_lesson');
  end if;

  perform public.expire_reservations();

  -- one open reservation per lesson: a new request abandons the old one (no hoarding of space by retrying)
  for r in select * from public.upload_reservations where lesson_id = p_lesson and status = 'reserved' for update loop
    perform public._release_reservation(r.id, 'released');
  end loop;
  select count(*) into n from public.upload_reservations where owner = p_owner and status = 'reserved';
  if n >= 3 then return json_build_object('ok', false, 'reason', 'too_many_open'); end if;

  -- first active storage with room. Per candidate: lock the ACCOUNT, check the account total, then an atomic conditional UPDATE.
  for s in select id, account_ref from public.storages where active order by sort_order, created_at, id loop
    perform pg_advisory_xact_lock(hashtextextended('r2acct:' || s.account_ref, 0));
    select coalesce(sum(used_bytes + reserved_bytes), 0) into acct from public.storages where account_ref = s.account_ref;
    if acct + p_size > public.storage_cap_bytes() then continue; end if;
    update public.storages set reserved_bytes = reserved_bytes + p_size
     where id = s.id and active and used_bytes + reserved_bytes + p_size <= limit_bytes
     returning * into st;
    if found then got := true; exit; end if;
  end loop;
  if not got then return json_build_object('ok', false, 'reason', 'full'); end if;

  ext := lower(regexp_replace(coalesce(p_ext, 'mp4'), '[^A-Za-z0-9]', '', 'g'));
  if ext = '' or length(ext) > 5 then ext := 'mp4'; end if;
  rid := gen_random_uuid();
  k := 'v/' || p_lesson::text || '/' || rid::text || '.' || ext;
  insert into public.upload_reservations(id, storage_id, lesson_id, owner, storage_key, size_bytes)
  values (rid, st.id, p_lesson, p_owner, k, p_size);
  return json_build_object('ok', true, 'reservationId', rid, 'storageId', st.id, 'endpoint', st.endpoint, 'bucket', st.bucket,
    'secretName', st.secret_name, 'key', k, 'sizeBytes', p_size,
    'expiresAt', (select expires_at from public.upload_reservations where id = rid));
end $$;

-- ---------- 2) complete (called by upload-complete AFTER it did a HEAD on the object: p_actual_bytes = the real size, null = no object) ----------
-- {ok:true, storageId, key, sizeBytes} or {ok:false, reason: missing | no_object | size_mismatch | expired | lesson_gone | rejected, deleteObject?:true}
-- deleteObject = the object IS in the bucket and must go: it is already counted and queued, purge-deleted removes it (the function may also delete it at once).
create or replace function public.complete_upload(p_owner uuid, p_reservation uuid, p_actual_bytes bigint) returns json
language plpgsql security definer set search_path = public as $$
declare r public.upload_reservations; st public.storages; lesson_ok boolean; ok boolean;
begin
  select * into r from public.upload_reservations where id = p_reservation for update;
  if not found or r.owner is distinct from p_owner then return json_build_object('ok', false, 'reason', 'missing'); end if;
  if r.status = 'completed' then
    return json_build_object('ok', true, 'already', true, 'storageId', r.storage_id, 'key', r.storage_key);
  end if;
  if r.status = 'rejected' then return json_build_object('ok', false, 'reason', 'rejected', 'deleteObject', true); end if;

  if p_actual_bytes is null or p_actual_bytes <= 0 then
    perform public._release_reservation(r.id, 'released');
    return json_build_object('ok', false, 'reason', 'no_object');
  end if;

  select exists (select 1 from public.lessons where id = r.lesson_id) into lesson_ok;
  ok := r.status = 'reserved' and p_actual_bytes <= r.size_bytes and lesson_ok;

  if not ok then
    -- the object really is in the bucket: count it (so the counter never lies) and queue it for deletion
    if r.status = 'reserved' then
      update public.storages set reserved_bytes = greatest(reserved_bytes - r.size_bytes, 0), used_bytes = used_bytes + p_actual_bytes
       where id = r.storage_id returning * into st;
    else
      update public.storages set used_bytes = used_bytes + p_actual_bytes where id = r.storage_id returning * into st;
    end if;
    update public.upload_reservations set status = 'rejected' where id = r.id;
    insert into public.stored_files(storage_id, storage_key, size_bytes, lesson_id)
    values (r.storage_id, r.storage_key, p_actual_bytes, r.lesson_id) on conflict do nothing;
    insert into public.file_delete_queue(storage_id, storage_key, size_bytes)
    values (r.storage_id, r.storage_key, p_actual_bytes)
    on conflict (storage_id, storage_key) where status = 'pending' do nothing;
    insert into public.storage_log(storage_id, event, detail)
    values (r.storage_id, 'rejected_upload', jsonb_build_object('reservation', r.id, 'was', r.status, 'reserved', r.size_bytes, 'actual', p_actual_bytes));
    if st.used_bytes + st.reserved_bytes > st.limit_bytes then
      update public.storages set active = false where id = st.id;
      insert into public.storage_log(storage_id, event, detail) values (st.id, 'deactivated', '{"why":"over limit after a rejected upload"}'::jsonb);
    end if;
    return json_build_object('ok', false, 'deleteObject', true,
      'reason', case when not lesson_ok then 'lesson_gone' when r.status <> 'reserved' then 'expired' else 'size_mismatch' end);
  end if;

  update public.storages set used_bytes = used_bytes + p_actual_bytes, reserved_bytes = greatest(reserved_bytes - r.size_bytes, 0)
   where id = r.storage_id;
  insert into public.stored_files(storage_id, storage_key, size_bytes, lesson_id)
  values (r.storage_id, r.storage_key, p_actual_bytes, r.lesson_id);
  -- if the lesson already had a file, the AFTER UPDATE trigger queues the old one for deletion
  insert into public.lesson_sources(lesson_id, storage_id, storage_key)
  values (r.lesson_id, r.storage_id, r.storage_key)
  on conflict (lesson_id) do update set storage_id = excluded.storage_id, storage_key = excluded.storage_key;
  update public.upload_reservations set status = 'completed', completed_at = now() where id = r.id;
  return json_build_object('ok', true, 'storageId', r.storage_id, 'key', r.storage_key, 'sizeBytes', p_actual_bytes);
end $$;

-- the teacher cancelled / the upload failed before sending a byte: give the space back
create or replace function public.release_upload(p_owner uuid, p_reservation uuid) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.upload_reservations where id = p_reservation and owner = p_owner) then return false; end if;
  return public._release_reservation(p_reservation, 'released');
end $$;

-- ---------- 3) delete queue (purge-deleted) ----------
create or replace function public.queue_next(p_limit int default 20) returns setof public.file_delete_queue
language sql security definer set search_path = public as $$
  select * from public.file_delete_queue
   where status = 'pending' and attempts < 10
   order by id limit greatest(least(coalesce(p_limit, 20), 100), 1)
$$;

-- R2 confirmed the delete (or the object was already gone): NOW the space comes back. Safe to call twice.
create or replace function public.queue_done(p_id bigint) returns boolean
language plpgsql security definer set search_path = public as $$
declare q public.file_delete_queue;
begin
  update public.file_delete_queue set status = 'done', done_at = now() where id = p_id and status = 'pending' returning * into q;
  if not found then return false; end if;
  update public.storages set used_bytes = greatest(used_bytes - q.size_bytes, 0) where id = q.storage_id;
  delete from public.stored_files where storage_id = q.storage_id and storage_key = q.storage_key;
  return true;
end $$;

create or replace function public.queue_fail(p_id bigint, p_error text) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  update public.file_delete_queue
     set attempts = attempts + 1, last_error = left(coalesce(p_error, ''), 300),
         status = case when attempts + 1 >= 10 then 'dead' else status end
   where id = p_id and status = 'pending';
  return found;
end $$;

-- ---------- 4) reconcile: our counter vs the REAL size of the bucket (purge-deleted lists the bucket right before calling this) ----------
-- Switches the storage OFF when: the real size is within 512 MiB of its limit, or the two numbers disagree by more than 256 MiB
-- (+ what is in flight: open reservations and files completed / deleted in the last 10 minutes). Also switches OFF every storage of the
-- same Cloudflare account when the account total is within 512 MiB of the 8 GiB account cap. Only the admin (active = true) turns it back on.
create or replace function public.reconcile_storage(p_storage text, p_actual_bytes bigint) returns json
language plpgsql security definer set search_path = public as $$
declare st public.storages; drift bigint; tol bigint; recent bigint; acct bigint; killed boolean := false; killed_acct boolean := false;
begin
  if p_actual_bytes is null or p_actual_bytes < 0 then raise exception 'bad size'; end if;
  select * into st from public.storages where id = p_storage for update;
  if not found then return json_build_object('ok', false, 'reason', 'missing'); end if;
  drift := p_actual_bytes - st.used_bytes;
  select coalesce(sum(size_bytes), 0) into recent from (
    select size_bytes from public.stored_files where storage_id = st.id and created_at > now() - interval '10 minutes'
    union all
    select size_bytes from public.file_delete_queue where storage_id = st.id and status = 'done' and done_at > now() - interval '10 minutes'
  ) x;
  tol := 268435456 + st.reserved_bytes + recent;
  update public.storages set used_bytes = p_actual_bytes where id = st.id;
  if p_actual_bytes >= st.limit_bytes - 536870912 or abs(drift) > tol then
    update public.storages set active = false where id = st.id;
    killed := true;
  end if;
  select coalesce(sum(used_bytes), 0) into acct from public.storages where account_ref = st.account_ref;
  if acct >= public.storage_cap_bytes() - 536870912 then
    update public.storages set active = false where account_ref = st.account_ref and active;
    killed_acct := true;
  end if;
  insert into public.storage_log(storage_id, event, detail)
  values (st.id, case when killed or killed_acct then 'deactivated' else 'reconcile' end,
          jsonb_build_object('counter', st.used_bytes, 'actual', p_actual_bytes, 'drift', drift, 'tolerance', tol, 'accountTotal', acct));
  return json_build_object('ok', true, 'used', p_actual_bytes, 'drift', drift, 'deactivated', killed, 'accountDeactivated', killed_acct);
end $$;

-- housekeeping (the free database is small): old finished rows go
create or replace function public.storage_prune() returns json
language plpgsql security definer set search_path = public as $$
declare a int; b int; c int;
begin
  delete from public.upload_reservations where status <> 'reserved' and created_at < now() - interval '30 days';
  get diagnostics a = row_count;
  delete from public.file_delete_queue where status = 'done' and done_at < now() - interval '30 days';
  get diagnostics b = row_count;
  delete from public.storage_log where at < now() - interval '90 days';
  get diagnostics c = row_count;
  return json_build_object('reservations', a, 'queue', b, 'log', c);
end $$;

-- ---------- permissions ----------
alter table public.storages            enable row level security;
alter table public.upload_reservations enable row level security;
alter table public.stored_files        enable row level security;
alter table public.file_delete_queue   enable row level security;
alter table public.storage_log         enable row level security;

-- Supabase gives new tables to anon / authenticated by default: take everything back, then give only what the apps need.
revoke all on public.storages, public.upload_reservations, public.stored_files, public.file_delete_queue, public.storage_log from anon, authenticated;

-- Teacher (and admin) SEE the safe columns only: no endpoint, bucket, account or secret name.
grant select (id, name, kind, limit_bytes, used_bytes, reserved_bytes, active, sort_order) on public.storages to authenticated;
drop policy if exists storages_read on public.storages;
create policy storages_read on public.storages for select to authenticated using (public.is_staff());

-- Admin EDITS name / limit (never above 8 GiB: the CHECK) / on-off / order. used_bytes and reserved_bytes can never be written from the app.
-- New storages and endpoints / secrets are added from the Supabase dashboard (STORAGES_SETUP.md, part 4).
grant update (name, limit_bytes, active, sort_order) on public.storages to authenticated;
drop policy if exists storages_admin_update on public.storages;
create policy storages_admin_update on public.storages for update to authenticated
  using (public.is_role('admin')) with check (public.is_role('admin'));

-- the other four tables: no policy and no grant = nobody from the app reads or writes them
revoke all on function public.reserve_upload(uuid,uuid,bigint,text), public.complete_upload(uuid,uuid,bigint), public.release_upload(uuid,uuid),
  public.expire_reservations(), public._release_reservation(uuid,text), public.queue_next(int), public.queue_done(bigint),
  public.queue_fail(bigint,text), public.reconcile_storage(text,bigint), public.storage_prune(),
  public.storages_guard(), public.sources_storage_guard(), public.queue_file_on_source_change()
  from public, anon, authenticated;
grant execute on function public.reserve_upload(uuid,uuid,bigint,text), public.complete_upload(uuid,uuid,bigint), public.release_upload(uuid,uuid),
  public.expire_reservations(), public.queue_next(int), public.queue_done(bigint), public.queue_fail(bigint,text),
  public.reconcile_storage(text,bigint), public.storage_prune() to service_role;
