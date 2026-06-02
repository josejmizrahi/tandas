-- Auto-creates a public.profiles row whenever a new auth.users row lands.
-- Plugs the gap that groups_created_by_fkey (profiles(id)) hit on the
-- first real-world Apple sign-in: the canonical schema FK required a
-- profile that no trigger materialized. Smoke didn't catch this because
-- _smoke_money_flow seeds users via SECURITY DEFINER with profiles inline.

create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  derived_name text;
begin
  derived_name := coalesce(
    new.raw_user_meta_data->>'full_name',
    new.raw_user_meta_data->>'name',
    nullif(
      trim(
        coalesce(new.raw_user_meta_data->'name'->>'firstName', '') || ' ' ||
        coalesce(new.raw_user_meta_data->'name'->>'lastName', '')
      ),
      ''
    )
  );

  insert into public.profiles (id, display_name, phone)
  values (new.id, derived_name, new.phone)
  on conflict (id) do nothing;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_auth_user();

-- Backfill auth.users without profiles (covers founder + any tester
-- accounts created before this trigger landed).
insert into public.profiles (id, display_name, phone)
select u.id,
       coalesce(
         u.raw_user_meta_data->>'full_name',
         u.raw_user_meta_data->>'name',
         nullif(
           trim(
             coalesce(u.raw_user_meta_data->'name'->>'firstName', '') || ' ' ||
             coalesce(u.raw_user_meta_data->'name'->>'lastName', '')
           ),
           ''
         )
       ),
       u.phone
from auth.users u
left join public.profiles p on p.id = u.id
where p.id is null
on conflict (id) do nothing;
