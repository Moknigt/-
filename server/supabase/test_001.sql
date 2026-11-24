-- Local test of 001 with a stub of Supabase's auth schema. Not for production.
create role anon nologin; create role authenticated nologin;
create schema auth;
create table auth.users(id uuid primary key default gen_random_uuid(), raw_user_meta_data jsonb default '{}');
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('test.uid', true),'')::uuid $$;
grant usage on schema auth, public to authenticated, anon;
\i 001_accounts.sql
grant select, insert, update, delete on all tables in schema public to authenticated;
revoke insert, update, delete on public.grants, public.grant_log from authenticated;
revoke all on public.teacher_codes from authenticated;
revoke update on public.profiles from authenticated; grant update (full_name, phone, grade) on public.profiles to authenticated;
insert into auth.users(id) values ('00000000-0000-0000-0000-0000000000a1'),('00000000-0000-0000-0000-0000000000b1'),('00000000-0000-0000-0000-0000000000b2');
insert into public.teacher_codes values ('ABC123-XYZ789');
set role authenticated;
set test.uid = '00000000-0000-0000-0000-0000000000a1';
select 'claim wrong'  as t, public.claim_teacher('nope') as r;
select 'claim right'  as t, public.claim_teacher('abc123xyz789') as r;
select 'claim reuse'  as t, public.claim_teacher('ABC123-XYZ789') as r;
insert into public.chapters(id, owner, title, price) values ('11111111-1111-1111-1111-111111111111','00000000-0000-0000-0000-0000000000a1','Course',100);
insert into public.lessons(id, owner, chapter_id, title, src, price) values
 ('22222222-2222-2222-2222-222222222222','00000000-0000-0000-0000-0000000000a1','11111111-1111-1111-1111-111111111111','paid in course','yt',0),
 ('33333333-3333-3333-3333-333333333333','00000000-0000-0000-0000-0000000000a1',null,'free video','yt',0);
insert into public.lesson_sources values ('22222222-2222-2222-2222-222222222222','AAAAAAAAAAA',null,null),('33333333-3333-3333-3333-333333333333','BBBBBBBBBBB',null,null);
set test.uid = '00000000-0000-0000-0000-0000000000b1';
select 'student role' as t, role from public.profiles where id = auth.uid();
select 'student sees sources (expect 1 free)' as t, count(*) from public.lesson_sources;
select 'access paid' as t, public.access_lesson('22222222-2222-2222-2222-222222222222');
select 'access free' as t, public.access_lesson('33333333-3333-3333-3333-333333333333');
do $$ begin perform public.play_source('22222222-2222-2222-2222-222222222222'); raise exception 'LEAK'; exception when sqlstate '42501' then raise notice 'play_source locked OK'; end $$;
do $$ begin update public.profiles set role='teacher' where id=auth.uid(); raise exception 'ESCALATION'; exception when insufficient_privilege then raise notice 'role update blocked OK'; end $$;
do $$ begin perform public.teacher_grant(auth.uid(),'chapter','11111111-1111-1111-1111-111111111111','free'); raise exception 'STUDENT GRANT'; exception when sqlstate '42501' then raise notice 'student cannot grant OK'; end $$;
do $$ begin delete from public.lessons where id='33333333-3333-3333-3333-333333333333'; if found then raise exception 'STUDENT DELETE'; end if; raise notice 'student delete = 0 rows OK'; end $$;
set test.uid = '00000000-0000-0000-0000-0000000000a1';
select 'grant' as t, public.teacher_grant('00000000-0000-0000-0000-0000000000b1','chapter','11111111-1111-1111-1111-111111111111','cash') as gid \gset
set test.uid = '00000000-0000-0000-0000-0000000000b1';
select 'after cash grant' as t, public.access_lesson('22222222-2222-2222-2222-222222222222');
select 'play ok' as t, public.play_source('22222222-2222-2222-2222-222222222222');
set test.uid = '00000000-0000-0000-0000-0000000000b2';
select 'other student still locked' as t, public.access_lesson('22222222-2222-2222-2222-222222222222');
set test.uid = '00000000-0000-0000-0000-0000000000a1';
select 'revoke' as t, public.teacher_revoke(id) from public.grants where revoked_at is null;
select 'log lines (expect 2)' as t, count(*) from public.grant_log;
set test.uid = '00000000-0000-0000-0000-0000000000b1';
select 'after revoke' as t, public.access_lesson('22222222-2222-2222-2222-222222222222');
select 'student reads log (expect 0)' as t, count(*) from public.grant_log;
