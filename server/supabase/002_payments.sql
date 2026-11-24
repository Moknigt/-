-- STEP 2 of 3 (electronic payment with Paymob). Run AFTER 001_accounts.sql. Step 3 (storages) = 003_storages.sql (not written yet).
-- Rule: only the server (service_role, from the two Edge Functions) can mark an order paid. The app can only READ its own order status.

create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),   -- also sent to Paymob as special_reference
  student uuid not null references public.profiles(id) on delete cascade,
  target_type text not null check (target_type in ('lesson','chapter')),
  target_id uuid not null,
  amount_cents int not null check (amount_cents > 0),      -- decided by the server from the price table, never by the app
  currency text not null default 'EGP',
  status text not null default 'pending' check (status in ('pending','paid','failed','refunded','mismatch')),
  provider_intention text,
  provider_order text,
  provider_tx text,
  created_at timestamptz not null default now(),
  paid_at timestamptz
);
create index if not exists orders_student on public.orders(student, created_at desc);
alter table public.orders enable row level security;
drop policy if exists orders_read on public.orders;
create policy orders_read on public.orders for select to authenticated using (student = auth.uid() or public.is_staff());
revoke insert, update, delete on public.orders from authenticated, anon;

-- The app polls this until it says "paid", then asks access_lesson again.
create or replace function public.order_status(p_order uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select status from public.orders where id = p_order and student = auth.uid()), 'missing')
$$;
grant execute on function public.order_status(uuid) to authenticated;

-- Paid: open the content (mode "online") + log line. Safe to call twice (a second webhook does nothing).
create or replace function public.fulfill_order(p_order uuid, p_tx text) returns boolean
language plpgsql security definer set search_path = public as $$
declare o public.orders;
begin
  update public.orders set status = 'paid', paid_at = now(), provider_tx = p_tx
   where id = p_order and status in ('pending','failed') returning * into o;
  if not found then return false; end if;
  insert into public.grants(student, target_type, target_id, mode, granted_by)
  values (o.student, o.target_type, o.target_id, 'online', null)
  on conflict (student, target_type, target_id) where revoked_at is null do nothing;
  insert into public.grant_log(student, target_type, target_id, mode, action, by_user)
  values (o.student, o.target_type, o.target_id, 'online', 'grant', null);
  return true;
end $$;

-- Refund / void reported by Paymob: close the online grant (the log keeps both lines).
create or replace function public.refund_order(p_order uuid, p_tx text) returns boolean
language plpgsql security definer set search_path = public as $$
declare o public.orders; n int;
begin
  update public.orders set status = 'refunded', provider_tx = coalesce(p_tx, provider_tx)
   where id = p_order and status = 'paid' returning * into o;
  if not found then return false; end if;
  update public.grants set revoked_at = now()
   where student = o.student and target_type = o.target_type and target_id = o.target_id and mode = 'online' and revoked_at is null;
  get diagnostics n = row_count;
  if n > 0 then
    insert into public.grant_log(student, target_type, target_id, mode, action, by_user)
    values (o.student, o.target_type, o.target_id, 'online', 'revoke', null);
  end if;
  return true;
end $$;

-- failed / mismatch only from "pending" (a paid order is never downgraded).
create or replace function public.mark_order(p_order uuid, p_status text) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if p_status not in ('failed','mismatch') then raise exception 'bad status'; end if;
  update public.orders set status = p_status where id = p_order and status = 'pending';
  return found;
end $$;

revoke all on function public.fulfill_order(uuid,text), public.refund_order(uuid,text), public.mark_order(uuid,text) from public, anon, authenticated;
grant execute on function public.fulfill_order(uuid,text), public.refund_order(uuid,text), public.mark_order(uuid,text) to service_role;
