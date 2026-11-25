-- STEP 1 (Telegram + WhatsApp): the sign-up code can now go through 'tg' (Telegram, free, no cap) or 'wa' (WhatsApp, capped per month).
-- Run ONCE in Supabase: SQL Editor -> paste -> Run (after 007). Safe to re-run.
-- The WhatsApp cap counts REAL replies (inside otp_claim, when the code is about to be sent), so nobody can burn the cap with fake numbers.
-- otp_start only checks "is there room left" so the app can tell the student early. Month = Cairo calendar month.

alter table public.phone_otps add column if not exists channel text not null default 'wa';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'phone_otps_channel_chk') then
    alter table public.phone_otps add constraint phone_otps_channel_chk check (channel in ('wa', 'tg'));
  end if;
end $$;

create table if not exists public.otp_wa_usage (month date primary key, used int not null default 0);
alter table public.otp_wa_usage enable row level security;
revoke all on public.otp_wa_usage from anon, authenticated;

insert into public.app_settings(key, value) values ('wa_monthly_limit', '1000') on conflict (key) do nothing;

create or replace function public.otp_wa_limit() returns int
language sql stable security definer set search_path = public as $$
  select coalesce((select value::int from public.app_settings where key = 'wa_monthly_limit' and value ~ '^[0-9]{1,9}$'), 1000)
$$;
create or replace function public.otp_wa_month() returns date
language sql stable as $$ select date_trunc('month', now() at time zone 'Africa/Cairo')::date $$;

-- otp_start: same limits as before + channel. For 'wa' it refuses with wa_limit when the month is full (no counting here).
drop function if exists public.otp_start(text, text, text);
create or replace function public.otp_start(p_phone text, p_ref text, p_ip text, p_channel text default 'wa') returns jsonb
language plpgsql security definer set search_path = public as $$
declare n text := public.norm_phone(p_phone);
begin
  if p_channel not in ('wa', 'tg') then return jsonb_build_object('ok', false, 'reason', 'bad_channel'); end if;
  if n !~ '^[1-9][0-9]{7,14}$' then return jsonb_build_object('ok', false, 'reason', 'bad_phone'); end if;
  delete from public.phone_otps where created_at < now() - interval '1 day';
  if exists (select 1 from public.phone_otps where phone = n and created_at > now() - interval '55 seconds') then
    return jsonb_build_object('ok', false, 'reason', 'too_soon');
  end if;
  if (select count(*) from public.phone_otps where phone = n and created_at > now() - interval '1 hour') >= 5
     or (p_ip <> '' and (select count(*) from public.phone_otps where ip = p_ip and created_at > now() - interval '1 hour') >= 20) then
    return jsonb_build_object('ok', false, 'reason', 'limit');
  end if;
  if p_channel = 'wa'
     and coalesce((select u.used from public.otp_wa_usage u where u.month = public.otp_wa_month()), 0) >= public.otp_wa_limit() then
    return jsonb_build_object('ok', false, 'reason', 'wa_limit');
  end if;
  insert into public.phone_otps(phone, ref, ip, channel, expires_at) values (n, p_ref, coalesce(p_ip, ''), p_channel, now() + interval '10 minutes');
  return jsonb_build_object('ok', true);
end $$;

-- otp_claim: p_channel says where the message came from (wa-webhook = 'wa', the Telegram bot = 'tg'). A reference made for one channel is refused on the
-- other (so nobody can start on Telegram and make the server answer on WhatsApp uncounted). For 'wa' the counter goes up here, under a row lock.
drop function if exists public.otp_claim(text, text, text);
create or replace function public.otp_claim(p_from text, p_ref text, p_code_hash text, p_channel text default 'wa') returns jsonb
language plpgsql security definer set search_path = public as $$
declare r public.phone_otps; v_month date := public.otp_wa_month(); v_used int;
begin
  select * into r from public.phone_otps where ref = p_ref and verified_at is null and expires_at > now() order by id desc limit 1 for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'unknown_ref'); end if;
  if r.channel <> p_channel then return jsonb_build_object('ok', false, 'reason', 'wrong_channel'); end if;
  if r.phone <> public.norm_phone(p_from) then return jsonb_build_object('ok', false, 'reason', 'other_number'); end if;
  if r.code_hash is not null then return jsonb_build_object('ok', false, 'reason', 'already'); end if;
  if p_channel = 'wa' then
    insert into public.otp_wa_usage(month, used) values (v_month, 0) on conflict (month) do nothing;
    select u.used into v_used from public.otp_wa_usage u where u.month = v_month for update;
    if v_used >= public.otp_wa_limit() then return jsonb_build_object('ok', false, 'reason', 'wa_limit'); end if;
    update public.otp_wa_usage set used = used + 1 where month = v_month;
  end if;
  update public.phone_otps set code_hash = p_code_hash, expires_at = now() + interval '10 minutes' where id = r.id;
  return jsonb_build_object('ok', true);
end $$;

revoke execute on function public.otp_start(text, text, text, text), public.otp_claim(text, text, text, text),
  public.otp_wa_limit(), public.otp_wa_month() from public, anon, authenticated;
grant execute on function public.otp_start(text, text, text, text), public.otp_claim(text, text, text, text) to service_role;

-- To see the month: select * from public.otp_wa_usage order by month desc;
-- To change the cap:  update public.app_settings set value = '1000' where key = 'wa_monthly_limit';
