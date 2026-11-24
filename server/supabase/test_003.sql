-- Local test of 003 (run AFTER test_001.sql, same database "postgres"). Not for production.
--   psql -d postgres -f test_001.sql ; psql -d postgres -f test_003.sql ; bash test_003_race.sh
-- Every check is a PASS notice or an exception that stops the run (ON_ERROR_STOP).
\set ON_ERROR_STOP on
\c postgres

do $$ begin create role service_role nologin; exception when duplicate_object then null; end $$;
grant usage on schema public to service_role;
-- Supabase hands every new table to anon / authenticated: copy that, so the revokes inside 003 are really tested.
grant all on all tables in schema public to service_role;   -- the real service_role bypasses RLS and owns every grant; the stub needs them spelled out
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
create schema if not exists t; grant usage on schema t to public;
create or replace function t.ok(label text, cond boolean) returns void language plpgsql as $$
begin if cond then raise notice 'PASS: %', label; else raise exception 'FAIL: %', label; end if; end $$;

\i 003_storages.sql

-- ---------- fixtures ----------
insert into auth.users(id) values ('00000000-0000-0000-0000-0000000000a9') on conflict do nothing;
update public.profiles set role = 'teacher' where id = '00000000-0000-0000-0000-0000000000a1';
update public.profiles set role = 'admin'   where id = '00000000-0000-0000-0000-0000000000a9';
insert into public.storages(id, name, endpoint, bucket, account_ref, secret_name, sort_order) values
 ('s-a', 'Storage A',                'https://acct1.r2.cloudflarestorage.com', 'vid-a', 'acct1', 'R2_A', 1),
 ('s-b', 'Storage B',                'https://acct2.r2.cloudflarestorage.com', 'vid-b', 'acct2', 'R2_B', 2),
 ('s-c', 'Storage C (same account as A)', 'https://acct1.r2.cloudflarestorage.com', 'vid-c', 'acct1', 'R2_C', 3);
insert into public.lessons(id, owner, title, src) values
 ('aaaaaaaa-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000a1', 'up1', 'up'),
 ('aaaaaaaa-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000000a1', 'up2', 'up'),
 ('aaaaaaaa-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000000a1', 'up3', 'up'),
 ('aaaaaaaa-0000-0000-0000-000000000004', '00000000-0000-0000-0000-0000000000a1', 'up4', 'up'),
 ('aaaaaaaa-0000-0000-0000-000000000005', '00000000-0000-0000-0000-0000000000a1', 'yt-lesson', 'yt');

-- ---------- 1) the limit cannot be raised, secrets are only names ----------
do $$ begin
  insert into public.storages(name, endpoint, bucket, account_ref, secret_name, limit_bytes) values ('x','e','b','z','R2_Z', 8589934593);
  raise exception 'FAIL: a limit above 8 GiB was accepted';
exception when check_violation then raise notice 'PASS: limit above 8 GiB refused'; end $$;
do $$ begin
  insert into public.storages(name, endpoint, bucket, account_ref, secret_name) values ('x','e','b','z','a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6');
  raise exception 'FAIL: a key-looking secret_name was accepted';
exception when check_violation then raise notice 'PASS: key-looking secret_name refused'; end $$;
do $$ begin
  update public.storages set reserved_bytes = 8589934593 where id = 's-b';
  raise exception 'FAIL: reserved_bytes went above the limit';
exception when sqlstate '53100' then raise notice 'PASS: trigger refuses reserved above the limit (even for a superuser)'; end $$;

-- ---------- 2) who can see / change what ----------
set role authenticated; set test.uid = '00000000-0000-0000-0000-0000000000a1';          -- teacher
select t.ok('teacher sees the 3 storages', (select count(*) from public.storages) = 3);
do $$ begin perform endpoint from public.storages; raise exception 'FAIL: teacher read endpoint';
exception when insufficient_privilege then raise notice 'PASS: teacher cannot read endpoint / secret_name'; end $$;
do $$ begin update public.storages set used_bytes = 0; raise exception 'FAIL: teacher wrote used_bytes';
exception when insufficient_privilege then raise notice 'PASS: nobody writes used_bytes from the app'; end $$;
do $$ declare n int; begin update public.storages set limit_bytes = 1; get diagnostics n = row_count;
  if n > 0 then raise exception 'FAIL: teacher edited a storage'; end if; raise notice 'PASS: teacher edits 0 rows'; end $$;
do $$ begin perform 1 from public.file_delete_queue; raise exception 'FAIL: teacher read the delete queue';
exception when insufficient_privilege then raise notice 'PASS: delete queue closed to the app'; end $$;
do $$ begin perform 1 from public.upload_reservations; raise exception 'FAIL: teacher read reservations';
exception when insufficient_privilege then raise notice 'PASS: reservations closed to the app'; end $$;
do $$ begin perform public.reserve_upload('00000000-0000-0000-0000-0000000000a1', 'aaaaaaaa-0000-0000-0000-000000000001', 1);
  raise exception 'FAIL: app called reserve_upload';
exception when insufficient_privilege then raise notice 'PASS: reserve_upload is service_role only'; end $$;
do $$ begin perform public.queue_done(1); raise exception 'FAIL: app called queue_done';
exception when insufficient_privilege then raise notice 'PASS: queue_done is service_role only'; end $$;
set test.uid = '00000000-0000-0000-0000-0000000000b1';                                  -- student
select t.ok('student sees no storage', (select count(*) from public.storages) = 0);
set test.uid = '00000000-0000-0000-0000-0000000000a9';                                  -- admin
do $$ declare n int; begin update public.storages set limit_bytes = 5368709120 where id = 's-c'; get diagnostics n = row_count;
  if n <> 1 then raise exception 'FAIL: admin could not edit the limit'; end if; raise notice 'PASS: admin lowers a limit'; end $$;
do $$ begin update public.storages set limit_bytes = 9000000000 where id = 's-c'; raise exception 'FAIL: admin raised above 8 GiB';
exception when check_violation then raise notice 'PASS: admin cannot raise the limit above 8 GiB'; end $$;
do $$ begin update public.storages set endpoint = 'https://evil' where id = 's-c'; raise exception 'FAIL: admin changed endpoint from the app';
exception when insufficient_privilege then raise notice 'PASS: endpoint / secret only from the dashboard'; end $$;
reset role;
update public.storages set limit_bytes = 8589934592 where id = 's-c';

-- ---------- 3) reserve ----------
set role service_role;
select t.ok('too large (1 GiB + 1)', (public.reserve_upload('00000000-0000-0000-0000-0000000000a1','aaaaaaaa-0000-0000-0000-000000000001', 1073741825)->>'reason') = 'too_large');
select t.ok('zero size', (public.reserve_upload('00000000-0000-0000-0000-0000000000a1','aaaaaaaa-0000-0000-0000-000000000001', 0)->>'reason') = 'bad_size');
select t.ok('student refused', (public.reserve_upload('00000000-0000-0000-0000-0000000000b1','aaaaaaaa-0000-0000-0000-000000000001', 1000)->>'reason') = 'not_allowed');
select t.ok('YouTube lesson refused', (public.reserve_upload('00000000-0000-0000-0000-0000000000a1','aaaaaaaa-0000-0000-0000-000000000005', 1000)->>'reason') = 'not_your_lesson');
select (j->>'ok') ok1, (j->>'reservationId') rid1, (j->>'storageId') sid1
  from (select public.reserve_upload('00000000-0000-0000-0000-0000000000a1','aaaaaaaa-0000-0000-0000-000000000001', 1073741824) j) x \gset
select t.ok('1 GiB reserved on the FIRST storage', :'ok1' = 'true' and :'sid1' = 's-a');
select t.ok('s-a reserved = 1 GiB', (select reserved_bytes from public.storages where id = 's-a') = 1073741824);

-- s-a full (7 GiB used + 1 GiB reserved). s-c is empty but shares the account with s-a: it must be skipped. s-b is on another account.
reset role;
update public.storages set used_bytes = 7516192768 where id = 's-a';
set role service_role;
select (j->>'ok') ok2, (j->>'reservationId') rid2, (j->>'storageId') sid2
  from (select public.reserve_upload('00000000-0000-0000-0000-0000000000a1','aaaaaaaa-0000-0000-0000-000000000002', 1073741824) j) x \gset
select t.ok('account cap: empty s-c skipped, goes to s-b', :'ok2' = 'true' and :'sid2' = 's-b');
select t.ok('s-c untouched', (select reserved_bytes from public.storages where id = 's-c') = 0);

-- ---------- 4) complete ----------
select (j->>'ok') okc, (j->>'key') key2 from (select public.complete_upload('00000000-0000-0000-0000-0000000000a1', :'rid2', 524288000) j) x \gset
select t.ok('complete with a smaller real size', :'okc' = 'true');
select t.ok('s-b used = real size, reserved = 0', (select used_bytes = 524288000 and reserved_bytes = 0 from public.storages where id = 's-b'));
select t.ok('lesson_sources points to the file', (select storage_key from public.lesson_sources where lesson_id = 'aaaaaaaa-0000-0000-0000-000000000002') = :'key2');
select t.ok('complete twice = same answer, no double count',
  (public.complete_upload('00000000-0000-0000-0000-0000000000a1', :'rid2', 524288000)->>'already') = 'true'
  and (select used_bytes from public.storages where id = 's-b') = 524288000);
select t.ok('another teacher cannot complete it', (public.complete_upload('00000000-0000-0000-0000-0000000000a9', :'rid2', 1)->>'reason') = 'missing');

-- a file bigger than reserved: counted, queued, refused
select (j->>'reservationId') rid3 from (select public.reserve_upload('00000000-0000-0000-0000-0000000000a1','aaaaaaaa-0000-0000-0000-000000000003', 1073741824) j) x \gset
select t.ok('oversize refused + must be deleted',
  (public.complete_upload('00000000-0000-0000-0000-0000000000a1', :'rid3', 1073741825) ->> 'reason') = 'size_mismatch');
select t.ok('oversize file counted in used_bytes until purged', (select used_bytes from public.storages where id = 's-b') = 524288000 + 1073741825);
select t.ok('oversize file queued', (select count(*) from public.file_delete_queue where status = 'pending') = 1);
select t.ok('lesson 3 has no source', not exists (select 1 from public.lesson_sources where lesson_id = 'aaaaaaaa-0000-0000-0000-000000000003'));

-- a teacher cannot attach ANOTHER lesson's file to his lesson
reset role; set role authenticated; set test.uid = '00000000-0000-0000-0000-0000000000a1';
do $$ begin
  insert into public.lesson_sources(lesson_id, storage_id, storage_key)
  values ('aaaaaaaa-0000-0000-0000-000000000003', 's-b', (select storage_key from public.lesson_sources where lesson_id = 'aaaaaaaa-0000-0000-0000-000000000002'));
  raise exception 'FAIL: forged source accepted';
exception when insufficient_privilege then raise notice 'PASS: another lesson''s file cannot be attached'; end $$;
reset role; set role service_role;

-- purge: space comes back only when the delete is confirmed, once
select id as qid from public.queue_next(10) \gset
select t.ok('queue_next gives the oversize file', (select count(*) from public.queue_next(10)) = 1);
select t.ok('queue_done true', public.queue_done(:qid));
select t.ok('space is back after the confirmed delete', (select used_bytes from public.storages where id = 's-b') = 524288000);
select t.ok('queue_done twice = false, no double decrement', not public.queue_done(:qid) and (select used_bytes from public.storages where id = 's-b') = 524288000);

-- no object found by HEAD: the reservation is released
select (j->>'reservationId') rid3b from (select public.reserve_upload('00000000-0000-0000-0000-0000000000a1','aaaaaaaa-0000-0000-0000-000000000003', 1073741824) j) x \gset
select t.ok('no object: refused', (public.complete_upload('00000000-0000-0000-0000-0000000000a1', :'rid3b', null)->>'reason') = 'no_object');
select t.ok('no object: reserved back to 0', (select reserved_bytes from public.storages where id = 's-b') = 0);

-- expiry: an abandoned reservation gives the space back; a late upload is counted + queued
select (j->>'reservationId') rid4 from (select public.reserve_upload('00000000-0000-0000-0000-0000000000a1','aaaaaaaa-0000-0000-0000-000000000004', 1073741824) j) x \gset
reset role;
update public.upload_reservations set expires_at = now() - interval '1 minute' where id = :'rid4';
set role service_role;
select t.ok('expire_reservations expired 1', public.expire_reservations() = 1);
select t.ok('expired space is back', (select reserved_bytes from public.storages where id = 's-b') = 0);
select t.ok('late upload after expiry refused', (public.complete_upload('00000000-0000-0000-0000-0000000000a1', :'rid4', 1048576)->>'reason') = 'expired');
select t.ok('late upload counted (1 MiB)', (select used_bytes from public.storages where id = 's-b') = 524288000 + 1048576);
select id as qid2 from public.queue_next(10) \gset
select t.ok('late upload removed after purge', public.queue_done(:qid2) and (select used_bytes from public.storages where id = 's-b') = 524288000);

-- the 4th open reservation of one teacher is refused
select public.reserve_upload('00000000-0000-0000-0000-0000000000a1','aaaaaaaa-0000-0000-0000-000000000003', 1048576);
select public.reserve_upload('00000000-0000-0000-0000-0000000000a1','aaaaaaaa-0000-0000-0000-000000000004', 1048576);
select t.ok('3 open reservations = the limit per teacher',
  (select count(*) from public.upload_reservations where owner = '00000000-0000-0000-0000-0000000000a1' and status = 'reserved') = 3);
select t.ok('4th refused', (public.reserve_upload('00000000-0000-0000-0000-0000000000a1','aaaaaaaa-0000-0000-0000-000000000002', 1048576)->>'reason') = 'too_many_open');
select t.ok('same lesson again replaces its old reservation (still 3)',
  (public.reserve_upload('00000000-0000-0000-0000-0000000000a1','aaaaaaaa-0000-0000-0000-000000000004', 1048576)->>'ok') = 'true'
  and (select count(*) from public.upload_reservations where owner = '00000000-0000-0000-0000-0000000000a1' and status = 'reserved') = 3);

-- all storages full -> "full"
reset role;
update public.upload_reservations set status = 'released' where status = 'reserved';
update public.storages set reserved_bytes = 0;
update public.storages set used_bytes = 8589934592 - 1000, active = true;
set role service_role;
select t.ok('every storage full: refused', (public.reserve_upload('00000000-0000-0000-0000-0000000000a1','aaaaaaaa-0000-0000-0000-000000000001', 1048576)->>'reason') = 'full');
reset role;
update public.storages set used_bytes = 0;
update public.storages set used_bytes = 524288000 where id = 's-b';

-- ---------- 5) deleting the lesson deletes the file (queue) ----------
set role authenticated; set test.uid = '00000000-0000-0000-0000-0000000000a1';
do $$ declare n int; begin delete from public.lessons where id = 'aaaaaaaa-0000-0000-0000-000000000002'; get diagnostics n = row_count;
  if n <> 1 then raise exception 'FAIL: teacher could not delete his lesson'; end if; raise notice 'PASS: teacher deleted his lesson'; end $$;
reset role;
select t.ok('the lesson file is queued for deletion', (select count(*) from public.file_delete_queue where status = 'pending' and size_bytes = 524288000) = 1);
select t.ok('space still counted until R2 confirms', (select used_bytes from public.storages where id = 's-b') = 524288000);
set role service_role;
select id as qid3 from public.queue_next(10) \gset
select t.ok('after the confirmed delete the space is free', public.queue_done(:qid3) and (select used_bytes from public.storages where id = 's-b') = 0);
reset role;

-- ---------- 6) reconcile (kill switch) ----------
update public.stored_files set created_at = now() - interval '1 hour';
update public.file_delete_queue set done_at = now() - interval '1 hour' where status = 'done';
update public.storages set used_bytes = 1000000, reserved_bytes = 0, active = true;
set role service_role;
select t.ok('small drift: stays ON', (public.reconcile_storage('s-b', 1000000 + 1000)->>'deactivated') = 'false' and (select active from public.storages where id = 's-b'));
select t.ok('counter corrected to the real size', (select used_bytes from public.storages where id = 's-b') = 1001000);
select t.ok('big drift (+1 GiB): switched OFF', (public.reconcile_storage('s-b', 1001000 + 1073741824)->>'deactivated') = 'true' and not (select active from public.storages where id = 's-b'));
reset role;
update public.storages set active = true where id = 's-b';
set role service_role;
select t.ok('real size within 512 MiB of the limit: switched OFF',
  (public.reconcile_storage('s-b', 8053063680)->>'deactivated') = 'true' and not (select active from public.storages where id = 's-b'));
reset role;
update public.storages set used_bytes = 7516192768, active = true where id = 's-a';
update public.storages set used_bytes = 644245094,  active = true where id = 's-c';
set role service_role;
select t.ok('account total near 8 GiB: every storage of that account OFF',
  (public.reconcile_storage('s-a', 7516192768)->>'accountDeactivated') = 'true'
  and not (select active from public.storages where id = 's-a') and not (select active from public.storages where id = 's-c'));
select t.ok('storage_prune runs', (public.storage_prune()->>'log') is not null);
reset role;
select 'test_003 finished: every check above must say PASS' as done;
