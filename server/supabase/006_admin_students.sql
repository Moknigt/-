-- STEP 4c (release 58): the admin removes a STUDENT on the server. Run in Supabase: SQL Editor -> paste -> Run (after 001..005, once).
-- Same idea as remove_account (004): the row stays (history stays) but the account loses every right at once (active = false),
-- and the student's own app signs out the next time it opens with internet (my_status says removed).
-- Only a real admin on the server can call it. Answer: true = removed, false = no such student (or already removed).

create or replace function public.remove_student(p_email text, p_reason text default '') returns boolean
language plpgsql security definer set search_path = public as $$
declare t public.profiles;
begin
  if not public.is_role('admin') then raise exception 'admins only' using errcode = '42501'; end if;
  select * into t from public.profiles
   where role = 'student' and lower(email) = lower(trim(coalesce(p_email, ''))) and removed_at is null
   for update;
  if not found then return false; end if;
  update public.profiles
     set active = false, removed_at = now(), removed_by = auth.uid(), removed_reason = left(coalesce(p_reason, ''), 200)
   where id = t.id;
  return true;
end $$;

revoke execute on function public.remove_student(text, text) from public, anon;
grant execute on function public.remove_student(text, text) to authenticated;
