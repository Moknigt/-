-- RELEASE 64: phone check through WhatsApp (sign-up). The STUDENT writes first (free), the server answers with the code in the same chat. Run ONCE in Supabase: SQL Editor -> paste -> Run (after 006).
-- Flow: otp-start (reference) -> student sends it on WhatsApp -> wa-webhook checks the SENDER number and replies with the code -> otp-verify.
-- The code is made, sent and checked ONLY on the server. The app never sees the right code.
-- Safe to run with nothing else changed: enforcement is OFF until you switch it on (see the end of this file).

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.app_settings (key text primary key, value text not null);
insert into public.app_settings(key, value) values ('require_phone_otp', 'false') on conflict (key) do nothing;
alter table public.app_settings enable row level security;          -- no policy = only the service role / dashboard can touch it

alter table public.profiles add column if not exists phone_verified boolean not null default false;   -- the app can never write it (column grants of 004)

create table if not exists public.phone_otps (
  id bigserial primary key,
  phone text not null,                        -- digits only, international (20 1xxxxxxxxx): the number typed in the sign-up
  ref text not null default '',               -- short reference the student sends on WhatsApp (ties the chat to this sign-up)
  code_hash text,                             -- sha256(pepper:code); null until the student's WhatsApp message arrived; never the code
  token_hash text,                            -- set when the code was right: sha256(token); the app sends the token with the sign-up
  attempts int not null default 0,
  ip text not null default '',
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  verified_at timestamptz,
  consumed boolean not null default false
);
create index if not exists phone_otps_phone_idx on public.phone_otps (phone, created_at desc);
create index if not exists phone_otps_ref_idx on public.phone_otps (ref);
alter table public.phone_otps enable row level security;
revoke all on public.phone_otps from anon, authenticated;
revoke all on public.app_settings from anon, authenticated;

-- the SAME number rules as PhoneRules in the apps: Egyptian 01[0125]xxxxxxxx -> 20 + 1xxxxxxxxx, international +xxxxxxxx -> digits
create or replace function public.norm_phone(p text) returns text
language sql immutable as $$
  select case
    when regexp_replace(coalesce(p,''), '[^0-9+]', '', 'g') ~ '^01[0125][0-9]{8}$'
      then '20' || substr(regexp_replace(p, '[^0-9+]', '', 'g'), 2)
    else regexp_replace(coalesce(p,''), '[^0-9]', '', 'g')
  end
$$;

-- a sign-up asks for a code: only a reference is made now. Limits: 1 request per 55 s per phone, 5 per hour per phone, 20 per hour per IP.
create or replace function public.otp_start(p_phone text, p_ref text, p_ip text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare n text := public.norm_phone(p_phone);
begin
  if n !~ '^[1-9][0-9]{7,14}$' then return jsonb_build_object('ok', false, 'reason', 'bad_phone'); end if;
  delete from public.phone_otps where created_at < now() - interval '1 day';
  if exists (select 1 from public.phone_otps where phone = n and created_at > now() - interval '55 seconds') then
    return jsonb_build_object('ok', false, 'reason', 'too_soon');
  end if;
  if (select count(*) from public.phone_otps where phone = n and created_at > now() - interval '1 hour') >= 5
     or (p_ip <> '' and (select count(*) from public.phone_otps where ip = p_ip and created_at > now() - interval '1 hour') >= 20) then
    return jsonb_build_object('ok', false, 'reason', 'limit');
  end if;
  insert into public.phone_otps(phone, ref, ip, expires_at) values (n, p_ref, coalesce(p_ip,''), now() + interval '10 minutes');
  return jsonb_build_object('ok', true);
end $$;

-- the student's WhatsApp message arrived (called by wa-webhook). The code is accepted ONLY if the SENDER number is the number typed in the sign-up
-- (nobody can verify a number that is not theirs). One message = one code: a second message with the same reference gets nothing.
create or replace function public.otp_claim(p_from text, p_ref text, p_code_hash text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r public.phone_otps;
begin
  select * into r from public.phone_otps where ref = p_ref and verified_at is null and expires_at > now() order by id desc limit 1 for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'unknown_ref'); end if;
  if r.phone <> public.norm_phone(p_from) then return jsonb_build_object('ok', false, 'reason', 'other_number'); end if;
  if r.code_hash is not null then return jsonb_build_object('ok', false, 'reason', 'already'); end if;
  update public.phone_otps set code_hash = p_code_hash, expires_at = now() + interval '10 minutes' where id = r.id;
  return jsonb_build_object('ok', true);
end $$;

-- check a code against the LATEST request of the phone (a new request kills the older ones). 5 wrong tries, then a new request is needed.
create or replace function public.otp_check(p_phone text, p_code_hash text, p_token_hash text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare n text := public.norm_phone(p_phone); r public.phone_otps;
begin
  select * into r from public.phone_otps where phone = n and verified_at is null order by id desc limit 1 for update;
  if not found or r.expires_at < now() then return jsonb_build_object('ok', false, 'reason', 'expired'); end if;
  if r.code_hash is null then return jsonb_build_object('ok', false, 'reason', 'waiting'); end if;   -- the WhatsApp message did not arrive yet
  if r.attempts >= 5 then return jsonb_build_object('ok', false, 'reason', 'locked'); end if;
  if r.code_hash = p_code_hash then
    update public.phone_otps set verified_at = now(), token_hash = p_token_hash where id = r.id;
    return jsonb_build_object('ok', true);
  end if;
  update public.phone_otps set attempts = attempts + 1 where id = r.id;
  return jsonb_build_object('ok', false, 'reason', case when r.attempts + 1 >= 5 then 'locked' else 'wrong' end);
end $$;

revoke execute on function public.otp_start(text, text, text), public.otp_claim(text, text, text), public.otp_check(text, text, text) from public, anon, authenticated;
grant execute on function public.otp_start(text, text, text), public.otp_claim(text, text, text), public.otp_check(text, text, text) to service_role;

-- sign-up gate (replaces the trigger function of 004, same columns + phone_verified).
-- A sign-up that brings a phone_token is accepted only if the token is real, fresh (30 min) and unused; the token is then used up.
-- With require_phone_otp = 'true' a sign-up that has a phone but NO valid token is refused. Sign-ups without a phone (admin) are untouched.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  ph text := coalesce(new.raw_user_meta_data->>'phone', '');
  tok text := coalesce(new.raw_user_meta_data->>'phone_token', '');
  req boolean := coalesce((select value = 'true' from public.app_settings where key = 'require_phone_otp'), false);
  used boolean := false;
begin
  if ph <> '' and (req or tok <> '') then
    update public.phone_otps set consumed = true
     where id = (select id from public.phone_otps
                  where phone = public.norm_phone(ph) and not consumed and verified_at > now() - interval '30 minutes'
                    and token_hash = encode(extensions.digest(convert_to(tok, 'UTF8'), 'sha256'), 'hex')
                  order by id desc limit 1)
    returning true into used;
    if not coalesce(used, false) then raise exception 'phone_not_verified' using errcode = 'P0001'; end if;
  end if;
  insert into public.profiles(id, full_name, phone, grade, email, phone_verified)
  values (new.id,
          coalesce(new.raw_user_meta_data->>'full_name',''),
          ph,
          coalesce(new.raw_user_meta_data->>'grade',''),
          coalesce(new.email,''),
          coalesce(used, false));
  return new;
end $$;

-- TO SWITCH THE GATE ON (only when every app you ship asks for the code; iPhone and Windows do not yet):
--   update public.app_settings set value = 'true' where key = 'require_phone_otp';
-- TO SWITCH IT OFF AGAIN:
--   update public.app_settings set value = 'false' where key = 'require_phone_otp';
