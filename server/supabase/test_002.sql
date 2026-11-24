-- Local test of 002 (run after test_001 objects exist). Not for production.
\c postgres
create role service_role nologin; grant usage on schema public to service_role;
\i 002_payments.sql
grant select on public.orders to authenticated;
reset role; set test.uid = '';
insert into public.chapters(id, owner, title, price) values ('44444444-4444-4444-4444-444444444444','00000000-0000-0000-0000-0000000000a1','Paid course 2',200);
insert into public.lessons(id, owner, chapter_id, title, src) values ('55555555-5555-5555-5555-555555555555','00000000-0000-0000-0000-0000000000a1','44444444-4444-4444-4444-444444444444','L','yt');
insert into public.lesson_sources values ('55555555-5555-5555-5555-555555555555','CCCCCCCCCCC',null,null);
insert into public.orders(id, student, target_type, target_id, amount_cents) values ('66666666-6666-6666-6666-666666666666','00000000-0000-0000-0000-0000000000b2','chapter','44444444-4444-4444-4444-444444444444',20000);
set role authenticated; set test.uid='00000000-0000-0000-0000-0000000000b2';
select 'status pending' t, public.order_status('66666666-6666-6666-6666-666666666666');
select 'locked before pay' t, (public.access_lesson('55555555-5555-5555-5555-555555555555')->>'allowed') allowed;
do $$ begin perform public.fulfill_order('66666666-6666-6666-6666-666666666666','tx1'); raise exception 'APP CAN FULFILL'; exception when insufficient_privilege then raise notice 'student cannot fulfill OK'; end $$;
do $$ begin update public.orders set status='paid'; if found then raise exception 'APP UPDATES ORDERS'; end if; exception when insufficient_privilege then raise notice 'student cannot update orders OK'; end $$;
reset role; set role service_role;
select 'fulfill' t, public.fulfill_order('66666666-6666-6666-6666-666666666666','tx1');
select 'fulfill twice' t, public.fulfill_order('66666666-6666-6666-6666-666666666666','tx1');
reset role; set role authenticated; set test.uid='00000000-0000-0000-0000-0000000000b2';
select 'status paid' t, public.order_status('66666666-6666-6666-6666-666666666666');
select 'open after pay' t, (public.access_lesson('55555555-5555-5555-5555-555555555555')->>'allowed') allowed;
select 'other order' t, public.order_status('77777777-7777-7777-7777-777777777777');
reset role; set role service_role;
select 'refund' t, public.refund_order('66666666-6666-6666-6666-666666666666','tx2');
select 'mark paid->failed (expect f)' t, public.mark_order('66666666-6666-6666-6666-666666666666','failed');
reset role; set role authenticated; set test.uid='00000000-0000-0000-0000-0000000000b2';
select 'locked after refund' t, (public.access_lesson('55555555-5555-5555-5555-555555555555')->>'allowed') allowed;
reset role;
select 'log online lines (expect 2)' t, count(*) from public.grant_log where mode='online';
