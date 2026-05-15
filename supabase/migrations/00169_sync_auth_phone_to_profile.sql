-- Mig 00169: Sync auth.users.phone → profiles.phone
--
-- Constitution: Layer 0 Identity. `profiles.phone` existed since 00001 but had
-- no writer: Supabase's OTP verify sets `auth.users.phone`, never the public
-- mirror. Clients reading profile.phone after a successful signup got NULL.
--
-- Two-pronged fix:
--   1. handle_new_user (signup trigger) seeds phone on initial INSERT.
--   2. New AFTER UPDATE OF phone trigger on auth.users mirrors later changes
--      (re-OTP, phone change, anon→phone upgrade).
--   3. One-shot backfill for existing rows that trail.
--
-- SECURITY DEFINER is required: the trigger function writes public.profiles
-- (RLS-protected). Identity is enforced by FK match `p.id = NEW.id`.

-- 1) handle_new_user: include phone on first insert
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, display_name, phone)
  values (
    new.id,
    coalesce(
      new.raw_user_meta_data->>'display_name',
      nullif(split_part(new.email, '@', 1), ''),
      'Usuario'
    ),
    new.phone
  )
  on conflict (id) do nothing;
  return new;
end;
$$;
revoke execute on function public.handle_new_user() from public, anon, authenticated;

-- 2) Sync trigger on auth.users.phone update
create or replace function public.sync_user_phone_to_profile()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.phone is distinct from old.phone then
    update public.profiles
       set phone = new.phone,
           updated_at = now()
     where id = new.id;
  end if;
  return new;
end;
$$;
revoke execute on function public.sync_user_phone_to_profile() from public, anon, authenticated;

drop trigger if exists on_auth_user_phone_sync on auth.users;
create trigger on_auth_user_phone_sync
  after update of phone on auth.users
  for each row execute function public.sync_user_phone_to_profile();

-- 3) Backfill profiles where phone trails auth.users
update public.profiles p
   set phone = u.phone,
       updated_at = now()
  from auth.users u
 where p.id = u.id
   and u.phone is not null
   and (p.phone is null or p.phone is distinct from u.phone);
